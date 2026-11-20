package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "machine.watchers", Group: d.GroupMachine, Name: "Checking file watchers", OS: "linux", Run: fileWatchers})
}

// procRoot is where /proc lives, so tests can build one.
var procRoot = "/proc"

// Dev servers, test runners and editors watch every file in a project. When the kernel's per-user limit runs out they
// fail with "ENOSPC: System limit for number of file watchers reached", which reads like a full disk. Ubuntu's 65,536 is
// plenty for most people, so the limit alone is not a problem: what is in use against it is.
func fileWatchers(e *host.Env) []d.Result {
	if e.Platform().InContainer() {
		return []d.Result{d.Skip("No file watcher check inside a container: the limit is the host's")}
	}
	b, err := os.ReadFile(filepath.Join(procRoot, "sys", "fs", "inotify", "max_user_watches"))
	if err != nil {
		return []d.Result{d.Skip("Could not read the file watcher limit")}
	}
	limit, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || limit <= 0 {
		return []d.Result{d.Err("The file watcher limit is not a number")}
	}
	used := WatchesInUse(procRoot)
	raise := fmt.Sprintf("fs.inotify.max_user_watches=%d", 524288)
	fix := func(r d.Result) d.Result {
		return r.With("To raise it now: sudo sysctl " + raise + ". To keep it after a restart, put that setting in a file in /etc/sysctl.d, such as /etc/sysctl.d/60-file-watchers.conf. Removing the file undoes it.").
			Manual(asRoot(e, []string{"sysctl", raise})...)
	}
	switch {
	case used*10 >= limit*8:
		return []d.Result{fix(d.Warn(fmt.Sprintf("Your apps are using %d of %d file watchers", used, limit)).
			With("Dev servers and editors will soon fail with ENOSPC, which looks like a full disk but is not."))}
	case limit < 16384:
		return []d.Result{fix(d.Note(fmt.Sprintf("The file watcher limit is low (%d)", limit)).
			With("Watching a large project fails with ENOSPC, which looks like a full disk but is not."))}
	}
	return []d.Result{d.Pass(fmt.Sprintf("File watchers: %d of %d in use", used, limit))}
}

// WatchesInUse counts the inotify watches held by the processes this user can see. Each inotify descriptor's fdinfo
// lists one "inotify wd:" line per watch. Other users' processes are unreadable, and their watches do not count
// against this user's limit anyway.
func WatchesInUse(proc string) int {
	n := 0
	fds, _ := filepath.Glob(filepath.Join(proc, "[0-9]*", "fd", "*"))
	for _, fd := range fds {
		if l, err := os.Readlink(fd); err != nil || l != "anon_inode:inotify" {
			continue
		}
		dir := filepath.Dir(filepath.Dir(fd))
		b, err := os.ReadFile(filepath.Join(dir, "fdinfo", filepath.Base(fd)))
		if err != nil {
			continue
		}
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "inotify wd:") {
				n++
			}
		}
	}
	return n
}
