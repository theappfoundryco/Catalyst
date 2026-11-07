package checks

import (
	"strings"
	"time"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "machine.docker", Group: d.GroupMachine, Name: "Checking Docker", Run: dockerState})
}

func lines(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

func dockerState(e *host.Env) []d.Result {
	if _, err := e.Look("docker"); err != nil {
		return []d.Result{d.Skip("Docker is not installed")}
	}
	if r := e.Run.Run(8*time.Second, "docker", "info", "--format", "{{.ServerVersion}}"); !r.OK() {
		return []d.Result{d.Skip("Docker is installed but not running")}
	}
	var out []d.Result
	if s, ok := e.Out("docker", "ps", "-aq", "-f", "status=exited"); ok {
		if n := lines(s); n > 0 {
			out = append(out, d.Note(ui.Count(n, "stopped Docker container is", "stopped Docker containers are")+" still taking up space").Run("docker", "container", "prune", "-f"))
		}
	}
	if s, ok := e.Out("docker", "images", "-q", "-f", "dangling=true"); ok {
		if n := lines(s); n > 0 {
			out = append(out, d.Note(ui.Count(n, "unused Docker image is", "unused Docker images are")+" still taking up space").Run("docker", "image", "prune", "-f"))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("Docker is running and tidy")}
	}
	return out
}
