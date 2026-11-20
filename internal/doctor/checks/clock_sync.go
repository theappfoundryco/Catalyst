package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "machine.clock", Group: d.GroupMachine, Name: "Checking the clock", OS: "linux", Run: clockSync})
}

// A clock that drifts by minutes breaks TLS ("certificate is not yet valid"), package signatures and cloud logins, and
// the errors never mention time. systemd knows both whether time sync is on and whether the kernel considers the clock
// synchronised. Only both being off is reported: chrony or ntpd keep the clock in sync with systemd's own service off.
func clockSync(e *host.Env) []d.Result {
	if e.Platform().InContainer() {
		return []d.Result{d.Skip("No clock check inside a container: the clock is the host's")}
	}
	if _, err := e.Look("timedatectl"); err != nil {
		return []d.Result{d.Skip("No timedatectl here")}
	}
	s, ok := e.Out("timedatectl", "show", "-p", "NTP", "-p", "NTPSynchronized", "-p", "CanNTP")
	if !ok {
		return []d.Result{d.Skip("Could not ask timedatectl")}
	}
	f := map[string]string{}
	for _, l := range strings.Split(s, "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(l), "="); ok {
			f[k] = v
		}
	}
	switch {
	case f["NTPSynchronized"] == "yes":
		return []d.Result{d.Pass("The clock is in sync")}
	case f["NTP"] == "no" && f["CanNTP"] == "yes":
		return []d.Result{d.Note("The clock is not kept in sync").
			With("A drifting clock breaks TLS and package downloads with errors that never mention time.").
			Manual(asRoot(e, []string{"timedatectl", "set-ntp", "true"})...)}
	case f["NTP"] == "yes":
		return []d.Result{d.Skip("Time sync is on, and has not caught up yet")}
	}
	return []d.Result{d.Skip("This machine cannot sync its clock with systemd")}
}
