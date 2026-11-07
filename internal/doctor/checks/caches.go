package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "machine.caches", Group: d.GroupMachine, Name: "Measuring developer caches", Run: caches})
}

func caches(e *host.Env) []d.Result {
	var big []string
	var total int64
	for _, g := range sweep.Globals(e) {
		if !host.Exists(g.Path) {
			continue
		}
		if size := sweep.DirSize(g.Path, sweep.NewSeen()); size > 2*gb {
			big = append(big, g.Title)
			total += size
		}
	}
	if len(big) == 0 {
		return []d.Result{d.Pass("Developer caches are a normal size")}
	}
	return []d.Result{d.Note("Caches are using " + ui.Size(total) + " (" + strings.Join(big, ", ") + ")").With("They rebuild themselves: catalyst sweep")}
}
