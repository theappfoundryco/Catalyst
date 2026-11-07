package checks

import (
	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "machine.memory", Group: d.GroupMachine, Name: "Checking memory", Run: memorySwap})
}

func memorySwap(e *host.Env) []d.Result {
	m, ok := e.Memory()
	if !ok {
		return []d.Result{d.Skip("Could not read memory")}
	}
	if m.SwapUsed > 4*gb {
		return []d.Result{d.Warn("This machine is using " + ui.RAM(m.SwapUsed) + " of swap").With("It has run out of memory for what is open, and everything is slower for it.")}
	}
	return []d.Result{d.Pass(ui.RAM(m.Total) + " of memory, no heavy swapping")}
}
