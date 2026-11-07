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
	"github.com/theappfoundryco/catalyst/internal/session"
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
	fs := a.flags("ports", "[stop | kill PORT] [--yes] [--json]")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	if fs.NArg() == 1 && fs.Arg(0) == "stop" {
		return a.pickPort()
	}
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
	a.outcome.Refresh = true
	u.Hdr("What is listening")
	if len(list) == 0 {
		u.Say("  " + u.Dim("Nothing that this user can see."))
		u.Blank()
		return ExitOK
	}
	open, stoppable := 0, 0
	var guarded []string
	for _, l := range list {
		if wide(l) {
			open++
		}
		if a.canStop(l) {
			stoppable++
		} else if protectedProcs[l.Command] {
			guarded = append(guarded, fmt.Sprintf("%s (%d)", l.Command, l.Port))
		}
	}
	head := u.Bold(ui.Count(len(list), "program is listening", "programs are listening"))
	if open > 0 {
		head += u.Faint("  ·  ") + u.Orange(fmt.Sprintf("%d can be reached from your network", open))
	}
	u.Say("  " + head)
	u.Blank()
	nameW := 8
	for _, l := range list {
		if n := len(l.Command); n > nameW {
			nameW = n
		}
	}
	if nameW > 24 {
		nameW = 24
	}
	u.Say("  " + u.Faint(fmt.Sprintf("%-7s %-*s  %-7s %s", "PORT", nameW, "PROGRAM", "PID", "REACHABLE FROM")))
	for _, l := range list {
		l := l
		name := l.Command
		if name == "" {
			name = "(another user's)"
		}
		reach := u.Faint("● ") + u.Dim("this machine only")
		if wide(l) {
			reach = u.Orange("● your whole network")
		}
		pid := ""
		if l.PID > 0 {
			pid = strconv.Itoa(l.PID)
		}
		if protectedProcs[l.Command] {
			reach += u.Faint("  protected")
		}
		keys := []session.Action{a.page("⏎", "details", fmt.Sprintf("Port %d", l.Port), func() { a.portDetails(l) })}
		if a.canStop(l) {
			keys = append(keys, goTo("s", "stop it", "Ports", "ports", "kill", strconv.Itoa(l.Port)))
		}
		keys = append(keys, a.urlKey("w", "open in browser", fmt.Sprintf("http://localhost:%d", l.Port)))
		u.Say(fmt.Sprintf("  %s%s %s  %s %s", a.row(keys...), u.Accent(fmt.Sprintf("%-7d", l.Port)), fmt.Sprintf("%-*s", nameW, ui.Fit(name, nameW)), u.Faint(fmt.Sprintf("%-7s", pid)), reach))
	}
	u.Blank()
	if stoppable > 0 {
		u.Warn("Stopping a port stops the program behind it. Unsaved work in it can be lost, and apps that rely on it may misbehave until it starts again.")
	}
	if len(guarded) > 0 {
		u.Note("Never stopped from here, because the system needs them: " + strings.Join(guarded, ", ") + ".")
	}
	switch {
	case stoppable == 0:
		u.Say("  " + u.Dim("None of these can be stopped from here: they belong to the system or another user."))
	case !a.inSession:
		u.Say("  " + u.Accent("i") + "  " + u.Dim("To stop one: ") + "catalyst ports stop" + u.Dim("  or  ") + "catalyst ports kill " + u.Accent("PORT"))
	}
	u.Blank()
	return ExitOK
}

// portDetails is everything known about one listener, for the screen a row opens.
func (a *App) portDetails(l host.Listener) {
	u := a.U
	u.Hdr(fmt.Sprintf("Port %d", l.Port))
	u.Row("Program", u.Bold(orDash(l.Command)))
	if l.PID > 0 {
		u.Row("Process", strconv.Itoa(l.PID))
	}
	if l.User != "" {
		u.Row("Runs as", l.User)
	}
	reach := "this machine only, at " + l.Address
	if wide(l) {
		reach = u.Orange("every network this machine is on")
	}
	u.Row("Reachable from", reach)
	if l.PID > 0 {
		if s, ok := a.E.Out("ps", "-o", "lstart=", "-p", strconv.Itoa(l.PID)); ok && s != "" {
			u.Row("Started", strings.Join(strings.Fields(s), " "))
		}
		if s, ok := a.E.Out("ps", "-o", "command=", "-p", strconv.Itoa(l.PID)); ok && s != "" {
			u.Row("Command", s)
		}
		if dir := a.E.Folder(l.PID); dir != "" {
			u.Row("Working in", a.E.Tilde(dir))
		}
	}
	u.Blank()
	switch {
	case protectedProcs[l.Command]:
		u.Note(l.Command + " is part of the system, so Catalyst never stops it.")
	case a.canStop(l):
		u.Hint("Stopping it quits " + l.Command + ". It is asked to quit first, and only forced if you say so.")
		a.outcome.Actions = append(a.outcome.Actions, goTo("s", "stop it", "Ports", "ports", "kill", strconv.Itoa(l.Port)))
	default:
		u.Note("It belongs to another user, so it can only be stopped as root.")
	}
	a.outcome.Actions = append(a.outcome.Actions, a.urlKey("w", "open in browser", fmt.Sprintf("http://localhost:%d", l.Port)),
		a.copyKey("y", "copy address", fmt.Sprintf("localhost:%d", l.Port), "the address"))
	u.Blank()
}

func orDash(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// wide says whether a listener answers on every network the machine is on, not only to itself.
func wide(l host.Listener) bool {
	return l.Address == "*" || l.Address == "0.0.0.0" || l.Address == "[::]" || l.Address == "::"
}

// canStop is true for what this user may stop: their own process, not part of the system, and not Catalyst.
func (a *App) canStop(l host.Listener) bool {
	return l.PID > 0 && !protectedProcs[l.Command] && l.PID != os.Getpid()
}

// pickPort lists what can be stopped and stops the one chosen, the same careful way as ports kill.
func (a *App) pickPort() int {
	u := a.U
	var can []host.Listener
	for _, l := range a.E.Listeners() {
		if a.canStop(l) {
			can = append(can, l)
		}
	}
	if len(can) == 0 {
		u.Say("  " + u.Dim("Nothing here can be stopped by this user."))
		return ExitOK
	}
	u.Say("  " + u.Bold("Which one should stop?") + u.Faint("  ·  ") + u.Dim("it is asked to quit, and only forced if you say so"))
	u.Blank()
	items := make([]ui.Item, len(can))
	for i, l := range can {
		about := fmt.Sprintf("Process %d", l.PID)
		if dir := a.E.Folder(l.PID); dir != "" {
			about += ", running in " + a.E.Tilde(dir)
		}
		reach := "this machine only"
		if wide(l) {
			reach = "your whole network"
		}
		items[i] = ui.Item{Label: fmt.Sprintf("%-6d %s", l.Port, l.Command), Right: reach, About: about}
	}
	m := &ui.Menu{Items: items, Single: true, Action: "stop", Cancel: "back"}
	if !m.Run(u) {
		a.outcome.SkipWait = true
		return ExitOK
	}
	return a.killPort(can[m.Chosen].Port)
}

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
	u.Hint("Stopping it quits " + l.Command + ". Unsaved work in it can be lost.")
	if !u.Ask("Stop it?") {
		return ExitOK
	}
	a.outcome.Changed = true
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
	a.outcome.Refresh = true
	u.Hdr("What starts by itself")
	if len(items) == 0 {
		u.Say("  " + u.Dim("Nothing found."))
	} else {
		u.Say("  " + u.Green("●") + u.Dim(" running   ") + u.Dim("-") + u.Dim(" not running now   ") + u.Red("✗") + u.Dim(" its program is gone"))
	}
	group := ""
	for _, it := range items {
		it := it
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
		keys := []session.Action{a.page("⏎", "details", it.Name, func() { a.startupDetails(it) })}
		if it.Path != "" {
			keys = append(keys, a.revealKey(it.Path))
		}
		if a.E.Mac() || it.Kind == "User service" || it.Kind == "System service" {
			keys = append(keys, goTo("t", "turn off", "Startup", "startup", "disable", it.Name))
		}
		line := "  " + a.row(keys...) + mark + " " + ui.Fit(it.Name, u.Width()-6)
		if it.Broken {
			line += u.Red("  its program is gone")
		}
		u.Say(line)
	}
	if a.E.Mac() {
		u.Blank()
		u.Say("  " + u.Dim("Apps you added under Login Items are in System Settings, General, Login Items."))
		if a.inSession {
			a.outcome.Actions = append(a.outcome.Actions, a.urlKey("L", "Login Items", settingsLoginItems))
		}
	}
	u.Blank()
	return ExitOK
}

// startupDetails is one startup item on its own screen.
func (a *App) startupDetails(it host.StartupItem) {
	u := a.U
	u.Hdr(it.Name)
	u.Row("Kind", it.Kind)
	state := u.Dim("not running now")
	if it.Loaded {
		state = u.Green("running")
	}
	u.Row("Now", state)
	if it.Program != "" {
		p := a.E.Tilde(it.Program)
		if it.Broken {
			p += u.Red("  (gone)")
		}
		u.Row("Runs", p)
	}
	if it.Path != "" {
		u.Row("Defined in", a.E.Tilde(it.Path))
		a.outcome.Actions = append(a.outcome.Actions, a.revealKey(it.Path), a.editKey(it.Path, 0))
	}
	who := "you"
	if !it.Mine {
		who = "the system (changing it needs your password)"
	}
	u.Row("Changed by", who)
	u.Blank()
	switch {
	case it.Broken:
		u.Warn("What it starts no longer exists, so it fails at every login. Turning it off is safe.")
	case a.E.Mac() && strings.HasPrefix(it.Name, "com.apple."):
		u.Note("This is part of macOS. Leave it on.")
	default:
		u.Hint("Turning it off stops it now and at every login. It is recorded, and you can turn it on again here or with: catalyst startup enable " + it.Name)
	}
	if a.E.Mac() || strings.Contains(it.Kind, "service") {
		a.outcome.Actions = append(a.outcome.Actions, goTo("t", "turn off", "Startup", "startup", "disable", it.Name),
			goTo("n", "turn on", "Startup", "startup", "enable", it.Name))
	}
	u.Blank()
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
		return a.toggleSystemStartup(it, action)
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
	a.outcome.Changed = true
	u.Ok(strings.ToUpper(action[:1]) + action[1:] + "d " + name)
	return ExitOK
}

// toggleSystemStartup changes an item that belongs to the system. Each command is shown first and runs only on a yes,
// through sudo's own password prompt.
func (a *App) toggleSystemStartup(it *host.StartupItem, action string) int {
	u := a.U
	var cmds [][]string
	switch {
	case a.E.Mac() && strings.HasPrefix(it.Name, "com.apple."):
		u.Stop(it.Name + " is part of macOS, so Catalyst leaves it alone.")
		return ExitIssues
	case a.E.Mac():
		domain := "system/"
		cmds = append(cmds, []string{"launchctl", action, domain + it.Name})
		if action == "disable" {
			cmds = append(cmds, []string{"launchctl", "bootout", domain + it.Name})
		}
	case it.Kind == "System service":
		cmds = append(cmds, []string{"systemctl", action, "--now", it.Name})
	default:
		u.Stop("Change this one by hand: " + it.Kind + " items are not managed here.")
		return ExitIssues
	}
	u.Say("  " + it.Name + u.Dim(" belongs to the system. This needs admin rights:"))
	for _, c := range cmds {
		u.Hint("sudo " + strings.Join(c, " "))
	}
	if !u.Ask(strings.ToUpper(action[:1]) + action[1:] + " " + it.Name + "?") {
		return ExitOK
	}
	if !a.sudoReady() {
		return ExitIssues
	}
	batch := journal.NewBatch(a.E.Now())
	for _, c := range cmds {
		if !a.asRoot(c...) && c[1] != "bootout" {
			u.Stop("That did not work, so it was left as it was.")
			return ExitIssues
		}
		a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: action + " " + it.Name, Command: append([]string{"sudo"}, c...)})
	}
	a.outcome.Changed = true
	u.Ok(strings.ToUpper(action[:1]) + action[1:] + "d " + it.Name)
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
		k := k
		mark := a.row(a.sshKeys(k, false)...)
		detail := strings.TrimSpace(fmt.Sprintf("%s %d", k.Type, k.Bits))
		safe := true
		if k.Private != "" && k.Mode&0o077 != 0 {
			safe = false
			u.Stop(fmt.Sprintf("%s%s  %s  other users can read it (%o)", mark, k.Name, u.Dim(detail), k.Mode))
			code = ExitIssues
		} else if k.Weak {
			safe = false
			u.Warn(fmt.Sprintf("%s%s  %s  weak, make a new one", mark, k.Name, u.Dim(detail)))
			code = ExitIssues
		}
		if safe {
			kind := ""
			if k.Private == "" {
				kind = u.Dim("  public half only")
			}
			u.Ok(mark + k.Name + "  " + u.Dim(detail) + kind)
		}
		if k.Fingerprint != "" {
			u.Hint(k.Fingerprint)
		}
	}
	if a.inSession && len(keys) > 0 {
		u.Blank()
		u.Say("  " + u.Dim("Public keys can be copied. Private keys never are: nothing should ask for one, and a copied private key can reach your other devices through the clipboard."))
	}
	u.Blank()
	return code
}

// sshKeys are the keys for one key pair. details is true on the key's own screen, where Enter would open nothing new.
func (a *App) sshKeys(k host.SSHKey, details bool) []session.Action {
	var keys []session.Action
	if !details {
		keys = append(keys, a.page("⏎", "details", k.Name, func() { a.sshDetails(k) }))
	}
	if k.Public != "" {
		if b, err := os.ReadFile(k.Public); err == nil {
			keys = append(keys, a.copyKey("y", "copy public key", strings.TrimSpace(string(b)), "the public key of "+k.Name))
		}
	}
	if k.Fingerprint != "" {
		keys = append(keys, a.copyKey("f", "copy fingerprint", k.Fingerprint, "the fingerprint"))
	}
	target := k.Private
	if target == "" {
		target = k.Public
	}
	return append(keys, a.revealKey(target))
}

// sshDetails is one key pair on its own screen: what it is, where it lives, and where it is used.
func (a *App) sshDetails(k host.SSHKey) {
	u := a.U
	u.Hdr(k.Name)
	u.Row("Kind", strings.TrimSpace(fmt.Sprintf("%s, %d bits", k.Type, k.Bits)))
	if k.Fingerprint != "" {
		u.Row("Fingerprint", k.Fingerprint)
	}
	if k.Comment != "" {
		u.Row("Label", k.Comment)
	}
	if k.Private != "" {
		perm := u.Green(fmt.Sprintf("%o, only you can read it", k.Mode))
		if k.Mode&0o077 != 0 {
			perm = u.Red(fmt.Sprintf("%o, other users can read it", k.Mode))
		}
		u.Row("Private half", a.E.Tilde(k.Private))
		u.Row("Permissions", perm)
	}
	if k.Public != "" {
		u.Row("Public half", a.E.Tilde(k.Public))
	}
	hosts := sshHosts(a.E.Path(".ssh", "config"), a.E.Home, k)
	if len(hosts) > 0 {
		u.Row("Used for", strings.Join(hosts, ", "))
	} else {
		u.Row("Used for", u.Dim("no Host in ~/.ssh/config names it"))
	}
	u.Blank()
	if k.Public != "" {
		u.Hint("To use it on GitHub, copy the public key and add it under Settings, SSH and GPG keys.")
		a.outcome.Actions = append(a.outcome.Actions, a.urlKey("g", "GitHub keys page", "https://github.com/settings/keys"))
	}
	a.outcome.Actions = append(a.sshKeys(k, true), a.outcome.Actions...)
	u.Blank()
}

// sshHosts reads ~/.ssh/config for the Host blocks whose IdentityFile is this key.
func sshHosts(config, home string, k host.SSHKey) []string {
	b, err := os.ReadFile(config)
	if err != nil {
		return nil
	}
	var out, current []string
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(strings.TrimSpace(line))
		if len(f) < 2 {
			continue
		}
		switch strings.ToLower(f[0]) {
		case "host":
			current = f[1:]
		case "identityfile":
			p := strings.Trim(f[1], `"`)
			p = strings.Replace(p, "~", home, 1)
			if p == k.Private || p+".pub" == k.Public || p == k.Public {
				out = append(out, current...)
			}
		}
	}
	return out
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
	a.outcome.Refresh = true
	u.Hdr("Your PATH, in the order it is searched")
	type entry struct {
		dir, note, src string
		line           int
		mark           string
	}
	seen := map[string]bool{}
	dead, dupes := 0, 0
	var rows []entry
	dirW := 6
	for _, p := range a.E.Entries {
		clean := filepath.Clean(p)
		st, err := os.Stat(p)
		e := entry{dir: p, mark: u.Green("✓")}
		switch {
		case seen[clean]:
			e.mark, e.note = u.Yellow("!"), "listed twice, so the second one does nothing"
			dupes++
		case err != nil || !st.IsDir():
			e.mark, e.note = u.Yellow("!"), "does not exist"
			dead++
		}
		seen[clean] = true
		e.src, e.line = a.pathSource(p)
		rows = append(rows, e)
		if n := len(a.E.Tilde(p)); n > dirW {
			dirW = n
		}
	}
	srcW := u.Width() - 2 - 3 - 2 - 2
	if dirW > srcW-14 {
		dirW = srcW - 14
	}
	srcW -= dirW
	u.Say("  " + u.Faint(fmt.Sprintf("%3s   %-*s  %s", "#", dirW, "FOLDER", "ADDED BY")))
	for i, e := range rows {
		keys := []session.Action{a.copyKey("y", "copy", e.dir, a.E.Tilde(e.dir))}
		if host.Exists(e.dir) {
			keys = append([]session.Action{a.revealKey(e.dir)}, keys...)
		}
		if e.src != "" && !strings.HasPrefix(e.src, "/etc/") {
			keys = append(keys, a.editKey(e.src, e.line))
		}
		src := u.Dim(ui.Fit(a.E.Tilde(e.src), srcW))
		if e.src == "" {
			src = u.Faint("macOS or the shell")
		}
		dir := ui.Fit(a.E.Tilde(e.dir), dirW)
		dir += strings.Repeat(" ", max(0, dirW-ui.Visible(dir)))
		u.Say(fmt.Sprintf("  %s%s %s %s  %s", a.row(keys...), u.Dim(fmt.Sprintf("%2d", i+1)), e.mark, dir, src))
		if e.note != "" {
			u.Say("        " + u.Yellow(e.note))
		}
	}
	if dead > 0 {
		u.Blank()
		u.Note("A folder that does not exist only slows each search a little. It is safe to leave.")
		u.Hint("To remove one you added, take it out of the file named beside it. One from /etc/paths.d was put there by an installer.")
	}
	u.Sect("Tools hidden by an earlier folder")
	shadows := a.shadows()
	if len(shadows) == 0 {
		u.Ok("Nothing is hidden")
	}
	type group struct {
		tool, winner string
		hidden       []string
	}
	var groups []*group
	byTool := map[string]*group{}
	for _, sh := range shadows {
		g, ok := byTool[sh.tool]
		if !ok {
			g = &group{tool: sh.tool, winner: sh.winner}
			byTool[sh.tool] = g
			groups = append(groups, g)
		}
		g.hidden = append(g.hidden, a.E.Tilde(filepath.Dir(sh.hidden)))
	}
	toolW := 4
	for _, g := range groups {
		if len(g.tool) > toolW {
			toolW = len(g.tool)
		}
	}
	for i, g := range groups {
		if i == 12 {
			u.Hint(fmt.Sprintf("and %d more", len(groups)-12))
			break
		}
		pad := strings.Repeat(" ", toolW+2)
		u.Say("  " + a.row(a.copyKey("y", "copy path", g.winner, "the path")) + u.Bold(fmt.Sprintf("%-*s", toolW, g.tool)) + "  " + u.Dim("runs   ") + a.E.Tilde(g.winner))
		u.Say("  " + pad + u.Dim("hides  "+strings.Join(g.hidden, ", ")))
	}
	if len(groups) > 0 {
		u.Blank()
		u.Hint("The first folder on the list wins. That is usually what you want. If not, move the folder you prefer earlier in your startup file.")
	}
	u.Blank()
	if dead+dupes > 0 {
		return ExitIssues
	}
	return ExitOK
}

// pathSource finds which startup file names a folder, and on which line, so an entry can actually be found and fixed.
// macOS's own lists in /etc/paths and /etc/paths.d count too.
func (a *App) pathSource(dir string) (string, int) {
	short := strings.Replace(dir, a.E.Home, "$HOME", 1)
	tilde := a.E.Tilde(dir)
	files := a.E.RCFiles()
	if a.E.Mac() {
		files = append(files, "/etc/paths")
		extra, _ := filepath.Glob("/etc/paths.d/*")
		files = append(files, extra...)
	}
	for _, rc := range files {
		b, err := os.ReadFile(rc)
		if err != nil {
			continue
		}
		for n, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "#") {
				continue
			}
			for _, needle := range []string{dir, short, tilde} {
				if strings.Contains(line, needle) {
					return rc, n + 1
				}
			}
		}
	}
	return "", 0
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
	fs := a.flags("config", "[set name NAME | set mascot on|off | set animations on|off]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	c := a.Store.LoadConfig()
	onOff := func(on bool) string {
		if on {
			return "on"
		}
		return "off"
	}
	if fs.NArg() == 0 {
		u.Hdr("Settings")
		name := c.Nickname()
		if name == "" {
			name = u.Dim("not set")
		}
		u.Row("Your name", a.row(goTo("⏎", "change", "Settings", "config", "set", "name"))+name)
		u.Row("Kit", a.row(goTo("⏎", "turn "+onOff(!c.MascotOn()), "Settings", "config", "set", "mascot", onOff(!c.MascotOn())))+onOff(c.MascotOn()))
		u.Row("Animations", a.row(goTo("⏎", "turn "+onOff(!c.MotionOn()), "Settings", "config", "set", "animations", onOff(!c.MotionOn())))+onOff(c.MotionOn())+u.Dim("  Kit's wag and the health dot's pulse"))
		u.Row("Files", a.E.Tilde(a.Store.ConfigDir))
		u.Row("History", a.E.Tilde(a.Store.Dir))
		u.Blank()
		return ExitOK
	}
	if fs.Arg(0) != "set" || fs.NArg() < 2 {
		fs.Usage()
		return ExitUsage
	}
	switch key := fs.Arg(1); key {
	case "name":
		name := strings.TrimSpace(strings.Join(fs.Args()[2:], " "))
		if fs.NArg() == 2 {
			name = strings.TrimSpace(u.Text("What should I call you? " + u.Dim("(Enter for no name) ")))
		}
		if len(name) > 24 {
			name = name[:24]
		}
		c.Name = &name
		if name == "" {
			u.Ok("No name. Catalyst just says hello.")
		} else {
			u.Ok("Hello, " + name + ".")
		}
	case "mascot", "animations":
		if fs.NArg() != 3 || (fs.Arg(2) != "on" && fs.Arg(2) != "off") {
			fs.Usage()
			return ExitUsage
		}
		on := fs.Arg(2) == "on"
		if key == "mascot" {
			c.Mascot = &on
			u.Ok("Kit is " + fs.Arg(2) + ".")
		} else {
			c.Motion = &on
			u.Ok("Animations are " + fs.Arg(2) + ". This takes effect the next time Catalyst opens.")
		}
	default:
		fs.Usage()
		return ExitUsage
	}
	if err := a.Store.SaveConfig(c); err != nil {
		u.Stop(err.Error())
		return ExitFailed
	}
	a.outcome.Changed = true
	return ExitOK
}
