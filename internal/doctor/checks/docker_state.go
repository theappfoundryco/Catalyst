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
		ctx, _ := e.Out("docker", "context", "show")
		return []d.Result{dockerUnreachable(e, r.Stdout+r.Stderr, ctx)}
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

// DockerFailure is why the docker command could not reach its engine, read from its own error.
type DockerFailure struct {
	Denied bool   // the engine is there, and this user may not use it
	Addr   string // the address docker tried, when it said
}

// ParseDockerError reads the error docker info prints when it cannot reach the engine. Docker 29 says "failed to
// connect to the docker API at ADDR" and "permission denied while trying to connect to the docker API at ADDR". Older
// releases said "Cannot connect to the Docker daemon at ADDR" and "...the Docker daemon socket at ADDR".
func ParseDockerError(s string) DockerFailure {
	low := strings.ToLower(s)
	f := DockerFailure{Denied: strings.Contains(low, "permission denied") && strings.Contains(low, "docker")}
	for _, k := range []string{" docker api at ", " docker daemon socket at ", " docker daemon at "} {
		if i := strings.Index(low, k); i >= 0 {
			rest := s[i+len(k):]
			if j := strings.IndexAny(rest, " ;\n"); j >= 0 {
				rest = rest[:j]
			}
			f.Addr = strings.TrimSuffix(strings.TrimSuffix(rest, "."), ",")
			break
		}
	}
	return f
}

// dockerUnreachable says why docker cannot reach its engine, and what would fix it. Docker not running is normal (Docker
// Desktop closed, Colima stopped), so it stays a skip with the way to start it. Only being locked out is a warning.
func dockerUnreachable(e *host.Env, msg, ctx string) d.Result {
	f := ParseDockerError(msg)
	if f.Denied {
		r := d.Warn("Docker is running, but your user is not allowed to use it")
		if e.Linux() {
			return r.With("Join the docker group, then log out and back in: sudo usermod -aG docker $USER. That group can act as root on this machine; rootless Docker or Podman avoids that.").
				Manual("sudo", "usermod", "-aG", "docker", "$USER")
		}
		return r.With("Docker Desktop's socket belongs to another user. Quit and reopen Docker Desktop as yourself.")
	}
	ctx = strings.TrimSpace(ctx)
	if ctx != "" && ctx != "default" && ctx != "desktop-linux" {
		start := "Start it, or switch back: docker context use default"
		if strings.HasPrefix(ctx, "colima") {
			start = "Start it with colima start, or switch back: docker context use default"
		}
		return d.Skip("Docker points at the " + ctx + " context, which is not running").With(start)
	}
	switch {
	case e.Mac():
		return d.Skip("Docker is installed but not running").With("Open Docker Desktop, or start your runtime (colima start, orb start).")
	case e.Platform().Init == "systemd" && !strings.Contains(f.Addr, "/run/user/"):
		return d.Skip("Docker is installed but not running").With("Start it: sudo systemctl start docker")
	case strings.Contains(f.Addr, "/run/user/"):
		return d.Skip("Rootless Docker is not running").With("Start it: systemctl --user start docker")
	}
	return d.Skip("Docker is installed but not running")
}
