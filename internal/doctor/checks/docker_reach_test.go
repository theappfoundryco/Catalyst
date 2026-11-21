package checks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Recorded from docker 29 in the docker:cli image (a user outside the docker group, and a Colima context with no
// Colima), and the older wording from earlier releases.
const (
	dockerDenied    = "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock\n"
	dockerDeadCtx   = "failed to connect to the docker API at unix:///Users/alex/.colima/default/docker.sock; check if the path is correct and if the daemon is running: dial unix /Users/alex/.colima/default/docker.sock: connect: no such file or directory\n"
	dockerOldDown   = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n"
	dockerOldDenied = "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.24/info\": dial unix /var/run/docker.sock: connect: permission denied\n"
)

func TestParseDockerError(t *testing.T) {
	cases := []struct {
		in     string
		denied bool
		addr   string
	}{
		{dockerDenied, true, "unix:///var/run/docker.sock"},
		{dockerOldDenied, true, "unix:///var/run/docker.sock:"},
		{dockerDeadCtx, false, "unix:///Users/alex/.colima/default/docker.sock"},
		{dockerOldDown, false, "unix:///var/run/docker.sock"},
		{"", false, ""},
	}
	for _, c := range cases {
		f := ParseDockerError(c.in)
		if f.Denied != c.denied || strings.TrimSuffix(f.Addr, ":") != strings.TrimSuffix(c.addr, ":") {
			t.Errorf("%q: %+v", c.in, f)
		}
	}
}

func TestDockerUnreachable(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"docker": "/usr/bin/docker"}, map[string]run.Result{
		"docker info --format {{.ServerVersion}}": {Code: 1, Stderr: dockerDenied},
		"docker context show":                     {Stdout: "default\n"},
	})
	e.SetPlatform(host.Platform{OS: "linux", Init: "systemd"})
	r := one(t, dockerState(e))
	if r.Severity != d.Warning || r.Fix == nil || r.Fix.Preview() != "sudo usermod -aG docker $USER" || !strings.Contains(r.Hint, "act as root") {
		t.Fatalf("%+v", r)
	}
	e.Run.(*run.Fake).Replies["docker info --format {{.ServerVersion}}"] = run.Result{Code: 1, Stderr: dockerOldDown}
	if r := one(t, dockerState(e)); r.State != d.Skipped || !strings.Contains(r.Hint, "systemctl start docker") {
		t.Fatalf("not running is normal, so a skip with the way to start it: %+v", r)
	}
	e.Run.(*run.Fake).Replies["docker context show"] = run.Result{Stdout: "colima\n"}
	e.Run.(*run.Fake).Replies["docker info --format {{.ServerVersion}}"] = run.Result{Code: 1, Stderr: dockerDeadCtx}
	if r := one(t, dockerState(e)); r.State != d.Skipped || r.Title != "Docker points at the colima context, which is not running" || !strings.Contains(r.Hint, "colima start") {
		t.Fatalf("%+v", r)
	}
}

func TestDockerVMDiskNearlyFull(t *testing.T) {
	old := vmDiskSmallest
	vmDiskSmallest = 1 << 20
	defer func() { vmDiskSmallest = old }()
	e, _ := env(t, "darwin", map[string]string{"docker": "/usr/local/bin/docker"}, map[string]run.Result{
		"docker info --format {{.ServerVersion}}": {Code: 1, Stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"},
		"docker context show":                     {Stdout: "desktop-linux\n"},
	})
	p := e.Path("Library", "Containers", "com.docker.docker", "Data", "vms", "0", "data", "Docker.raw")
	os.MkdirAll(filepath.Dir(p), 0o755)
	f, _ := os.Create(p)
	f.Truncate(8 << 20) // an 8 MB limit, with 7.5 MB written below
	f.Write(make([]byte, 7<<20+1<<19))
	f.Close()
	rs := dockerState(e)
	if len(rs) != 2 || rs[1].Severity != d.Warning || !strings.Contains(rs[1].Title, "Docker Desktop's virtual disk is 9") || !strings.Contains(rs[1].Hint, "docker system prune") {
		t.Fatalf("a full disk is said even while Docker will not start: %+v", rs)
	}
	f, _ = os.Create(p)
	f.Truncate(8 << 20)
	f.Write(make([]byte, 1<<20))
	f.Close()
	if rs := dockerState(e); len(rs) != 1 {
		t.Fatalf("an empty disk says nothing: %+v", rs)
	}
}
