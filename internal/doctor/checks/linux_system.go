package checks

import (
	"regexp"
	"strconv"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "machine.linux", Group: d.GroupMachine, Name: "Checking the system", OS: "linux", Run: linuxSystem})
}

var journalSize = regexp.MustCompile(`take up ([\d.]+)([MGT])`)

// JournalBytes reads journalctl --disk-usage.
func JournalBytes(s string) int64 {
	m := journalSize.FindStringSubmatch(s)
	if m == nil {
		return 0
	}
	v, _ := strconv.ParseFloat(m[1], 64)
	mult := map[string]float64{"M": 1e6, "G": 1e9, "T": 1e12}[m[2]]
	return int64(v * mult)
}

func linuxSystem(e *host.Env) []d.Result {
	var out []d.Result
	if host.Exists("/var/run/reboot-required") {
		out = append(out, d.Note("This machine is waiting for a restart to finish an update"))
	}
	if r := e.Run.Run(0, "journalctl", "--disk-usage"); r.OK() {
		if b := JournalBytes(r.Stdout + r.Stderr); b > 2*gb {
			out = append(out, d.Note("System logs are using "+ui.Size(b)).Manual("sudo", "journalctl", "--vacuum-size=500M"))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("No restart waiting, logs are a normal size")}
	}
	return out
}
