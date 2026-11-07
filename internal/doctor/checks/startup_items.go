package checks

import (
	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "machine.startup", Group: d.GroupMachine, Name: "Checking what starts by itself", Run: startupItems})
}

func startupItems(e *host.Env) []d.Result {
	var out []d.Result
	if e.Mac() {
		for _, it := range e.StartupItems() {
			if !it.Broken {
				continue
			}
			r := d.Warn(it.Name + " starts at login, but what it runs is gone").With(it.Program)
			if it.Mine {
				r = r.Trash(it.Path)
			}
			out = append(out, r)
		}
		if len(out) == 0 {
			return []d.Result{d.Pass("Everything that starts by itself still exists")}
		}
		return out
	}
	_, err := e.Look("systemctl")
	if err != nil {
		return []d.Result{d.Skip("No systemd here")}
	}
	seen := 0
	for _, scope := range [][]string{{"--failed"}, {"--user", "--failed"}} {
		args := append(scope, "--no-legend", "--plain")
		s, ok := e.Out("systemctl", args...)
		if !ok {
			continue
		}
		seen++
		for _, u := range host.ParseFailedUnits(s) {
			prefix := "systemctl status "
			if scope[0] == "--user" {
				prefix = "systemctl --user status "
			}
			out = append(out, d.Warn(u+" has failed").With("See why: "+prefix+u))
		}
	}
	if seen == 0 {
		return []d.Result{d.Skip("systemd is not running here")}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("No failed services")}
	}
	return out
}
