package checks

import (
	"fmt"
	"strconv"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "machine.disk", Group: d.GroupMachine, Name: "Checking free disk space", Run: diskFree})
}

const gb = 1000 * 1000 * 1000

func diskFree(e *host.Env) []d.Result {
	v, ok := e.HomeVolume()
	if !ok {
		return []d.Result{d.Skip("Could not read the disk")}
	}
	free := fmt.Sprintf("%s free of %s", ui.Size(v.Free), ui.Size(v.Size))
	freePct := 100 - v.UsedPercent
	var out []d.Result
	switch {
	case freePct < 5 || v.Free < 5*gb:
		out = append(out, d.Crit("Your disk is nearly full ("+free+")").With("Builds and updates will start to fail. See what can go: catalyst sweep"))
	case freePct < 15:
		out = append(out, d.Warn("Your disk is getting full ("+free+")").With("See what can go: catalyst sweep"))
	default:
		out = append(out, d.Pass(free))
	}
	if e.Linux() {
		if s, ok := e.Out("df", "-iP", e.Home); ok {
			if p, ok := InodePercent(s); ok && p >= 90 {
				out = append(out, d.Warn(fmt.Sprintf("%d%% of the disk's file slots are used", p)).With("New files can fail even with space free. node_modules folders are the usual cause: catalyst sweep"))
			}
		}
	}
	return out
}

// InodePercent reads df -iP.
func InodePercent(text string) (int, bool) {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) < 2 {
		return 0, false
	}
	f := strings.Fields(lines[len(lines)-1])
	if len(f) < 5 {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSuffix(f[4], "%"))
	return n, err == nil
}
