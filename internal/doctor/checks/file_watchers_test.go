package checks

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

// fakeProc builds a /proc with the given limit and one process holding watches inotify watches. The fdinfo text is the
// shape the kernel writes, with the inode numbers changed.
func fakeProc(t *testing.T, limit, watches int) string {
	t.Helper()
	root := t.TempDir()
	write(t, filepath.Join(root, "sys", "fs", "inotify", "max_user_watches"), strconv.Itoa(limit)+"\n", 0o644)
	pid := filepath.Join(root, "4242")
	os.MkdirAll(filepath.Join(pid, "fd"), 0o755)
	os.Symlink("anon_inode:inotify", filepath.Join(pid, "fd", "7"))
	os.Symlink("/dev/null", filepath.Join(pid, "fd", "0"))
	info := "pos:\t0\nflags:\t02004000\nmnt_id:\t15\nino:\t1057\n"
	for i := 1; i <= watches; i++ {
		info += "inotify wd:" + strconv.Itoa(i) + " ino:a1b2 sdev:800002 mask:fc6 ignored_mask:0 fhandle-bytes:8 fhandle-type:1 f_handle:00000000\n"
	}
	write(t, filepath.Join(pid, "fdinfo", "7"), info, 0o644)
	write(t, filepath.Join(pid, "fdinfo", "0"), "pos:\t0\n", 0o644)
	return root
}

func TestFileWatchers(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	defer func(p string) { procRoot = p }(procRoot)

	procRoot = fakeProc(t, 65536, 520)
	if r := one(t, fileWatchers(e)); r.State != d.Passed || r.Title != "File watchers: 520 of 65536 in use" {
		t.Fatalf("Ubuntu's default with normal use is fine: %+v", r)
	}
	procRoot = fakeProc(t, 1000, 900)
	if r := one(t, fileWatchers(e)); r.Severity != d.Warning || r.Fix == nil || !strings.Contains(r.Fix.Preview(), "sysctl fs.inotify.max_user_watches=524288") {
		t.Fatalf("%+v", r)
	}
	procRoot = fakeProc(t, 8192, 10)
	if r := one(t, fileWatchers(e)); r.Severity != d.Info {
		t.Fatalf("an old 8192 default is worth a note: %+v", r)
	}
	procRoot = t.TempDir()
	if r := one(t, fileWatchers(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "linux", Container: "docker"})
	if r := one(t, fileWatchers(e)); r.State != d.Skipped || !strings.Contains(r.Title, "host") {
		t.Fatalf("%+v", r)
	}
}
