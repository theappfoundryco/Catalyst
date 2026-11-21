package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
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
	disks := vmDisks(e)
	if r := e.Run.Run(8*time.Second, "docker", "info", "--format", "{{.ServerVersion}}"); !r.OK() {
		ctx, _ := e.Out("docker", "context", "show")
		return append([]d.Result{dockerUnreachable(e, r.Stdout+r.Stderr, ctx)}, disks...) // a full disk is often why it will not start
	}
	out := disks
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

// vmDisk is a virtual machine's disk that Docker or Podman keeps as a sparse file: its size is the limit you chose, and
// the blocks it has taken are what is used inside. So the VM can be nearly full while your Mac has plenty of room,
// and no message says which disk ran out.
type vmDisk struct{ owner, glob, grow string }

var vmDiskFiles = []vmDisk{
	{"Docker Desktop", "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "In Docker Desktop, Settings, Resources, raise the disk usage limit."},
	{"Docker Desktop", ".docker/desktop/vms/0/data/Docker.raw", "In Docker Desktop, Settings, Resources, raise the disk usage limit."},
	{"Podman", ".local/share/containers/podman/machine/*/*.raw", "Or give the machine more: podman machine stop, then podman machine set --disk-size with a bigger number (it can only grow)."},
}

// vmDiskSmallest leaves out files too small to be a VM's disk. A variable, so tests can use small sparse files.
var vmDiskSmallest int64 = 1 << 30

func vmDisks(e *host.Env) []d.Result {
	var out []d.Result
	for _, v := range vmDiskFiles {
		paths, _ := filepath.Glob(e.Path(v.glob))
		for _, p := range paths {
			limit, used, ok := sparseUse(p)
			if !ok || limit < vmDiskSmallest {
				continue
			}
			pct := int(used * 100 / limit)
			free := "docker system prune removes stopped containers, unused networks, dangling images and build cache."
			if v.owner == "Podman" {
				free = "podman system prune removes stopped containers, unused networks and dangling images."
			}
			msg := fmt.Sprintf("%s's virtual disk is %d%% full (%s of %s)", v.owner, pct, ui.Size(used), ui.Size(limit))
			switch {
			case pct >= 90:
				out = append(out, d.Warn(msg).With("Builds and pulls inside it fail with \"no space left on device\", even with room on this disk. "+free+" "+v.grow))
			case pct >= 80:
				out = append(out, d.Note(msg).With(free+" "+v.grow))
			}
		}
	}
	return out
}

// sparseUse reads a sparse file's size and the space it really takes. A file that is not sparse says nothing about
// what is used inside it, so it is left out.
func sparseUse(p string) (limit, used int64, ok bool) {
	st, err := os.Stat(p)
	if err != nil || !st.Mode().IsRegular() {
		return 0, 0, false
	}
	sys, isUnix := st.Sys().(*syscall.Stat_t)
	if !isUnix {
		return 0, 0, false
	}
	limit, used = st.Size(), int64(sys.Blocks)*512
	if used > limit {
		used = limit
	}
	return limit, used, limit > 0
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
