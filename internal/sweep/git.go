package sweep

import (
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
)

type verdict int

const (
	verdictYes     verdict = iota // git ignores it and tracks nothing in it
	verdictNo                     // git tracks something in it, or does not ignore it
	verdictUnknown                // git could not say, so treat it as no
)

// repoCache finds repositories without running a program per folder.
type repoCache struct {
	e  *host.Env
	mu sync.Mutex
	m  map[string]string
}

func newRepoCache(e *host.Env) *repoCache { return &repoCache{e: e, m: map[string]string{}} }

// root finds the repository holding dir, or "" when there is none. A .git file counts too, for worktrees and submodules.
func (c *repoCache) root(dir string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var walked []string
	cur := dir
	found := ""
	for {
		if v, ok := c.m[cur]; ok {
			found = v
			break
		}
		walked = append(walked, cur)
		if host.Exists(filepath.Join(cur, ".git")) {
			found = cur
			break
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	for _, w := range walked {
		c.m[w] = found
	}
	return found
}

// disposable asks git two separate questions. Ignored alone is not enough: a file can be tracked and ignored at once.
// Read-only and time-limited, with its fsmonitor off, since a daemon holding the pipe open has hung this before.
func (c *repoCache) disposable(repo, path string) verdict {
	gitPath, ok := c.e.SafeTool("git")
	if !ok {
		return verdictUnknown
	}
	rel, err := filepath.Rel(repo, path)
	if err != nil {
		return verdictUnknown
	}
	base := []string{"-C", repo, "-c", "core.fsmonitor=false"}
	ignored := c.e.Run.Run(15*time.Second, gitPath, append(base, "check-ignore", "-q", rel+"/")...)
	if ignored.TimedOut || ignored.NotFound {
		return verdictUnknown
	}
	if ignored.Code == 1 {
		return verdictNo
	}
	if ignored.Code != 0 {
		return verdictUnknown
	}
	tracked := c.e.Run.Run(15*time.Second, gitPath, append(base, "ls-files", "--", rel)...)
	if !tracked.OK() {
		return verdictUnknown
	}
	if strings.TrimSpace(tracked.Stdout) != "" {
		return verdictNo
	}
	return verdictYes
}
