package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "keys.firewall", Group: d.GroupKeys, Name: "Checking the firewall", Run: firewall})
}

func firewall(e *host.Env) []d.Result {
	if e.Mac() {
		s, ok := e.Out("/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate")
		if !ok {
			return []d.Result{d.Skip("Could not read the firewall")}
		}
		if strings.Contains(s, "enabled") || strings.Contains(s, "State = 1") {
			return []d.Result{d.Pass("The firewall is on")}
		}
		return []d.Result{d.Note("The firewall is off").With("Fine on a trusted network. Turn it on in System Settings, Network, Firewall.")}
	}
	if _, err := e.Look("firewall-cmd"); err == nil {
		if s, ok := e.Out("firewall-cmd", "--state"); ok && s == "running" {
			return []d.Result{d.Pass("The firewall (firewalld) is on")}
		}
		return []d.Result{d.Note("firewalld is installed but not running")}
	}
	if _, err := e.Look("ufw"); err == nil {
		if s, ok := e.Out("ufw", "status"); ok {
			if strings.Contains(s, "Status: active") {
				return []d.Result{d.Pass("The firewall (ufw) is on")}
			}
			return []d.Result{d.Note("The firewall (ufw) is off")}
		}
		return []d.Result{d.Skip("Reading ufw needs root")}
	}
	return []d.Result{d.Skip("No firewall tool here")}
}
