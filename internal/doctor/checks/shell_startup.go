package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "shell.startup", Group: d.GroupShell, Name: "Timing a new shell", Run: shellStartup})
}

// shellStartup times a new interactive shell. A slow one is felt every time a terminal opens.
func shellStartup(e *host.Env) []d.Result {
	if e.Shell == "" {
		return []d.Result{d.Skip("Could not tell which shell you use")}
	}
	name := filepath.Base(e.Shell)
	t0 := e.Now()
	r := e.Run.Run(15*time.Second, e.Shell, "-i", "-c", "exit")
	took := e.Now().Sub(t0)
	if r.NotFound {
		return []d.Result{d.Warn(fmt.Sprintf("Your shell %s is not there anymore", e.Shell))}
	}
	if r.TimedOut {
		return []d.Result{d.Warn(fmt.Sprintf("A new %s shell takes more than 15 seconds to start", name)).With(culprit(e))}
	}
	secs := fmt.Sprintf("%.1fs", took.Seconds())
	switch {
	case took >= time.Second:
		return []d.Result{d.Warn(fmt.Sprintf("New %s shells take %s to start", name, secs)).With(culprit(e))}
	case took >= 500*time.Millisecond:
		return []d.Result{d.Note(fmt.Sprintf("New %s shells take %s to start", name, secs)).With(culprit(e))}
	}
	return []d.Result{d.Pass(fmt.Sprintf("New %s shells start in %s", name, secs))}
}

// culprit names the usual suspects it can actually see in the startup files.
func culprit(e *host.Env) string {
	suspects := map[string]string{"nvm.sh": "nvm", "conda": "conda", "oh-my-zsh": "oh-my-zsh", "pyenv init": "pyenv", "rbenv init": "rbenv"}
	found := map[string]bool{}
	for _, f := range e.RCFiles() {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for needle, label := range suspects {
			if strings.Contains(string(b), needle) {
				found[label] = true
			}
		}
	}
	var names []string
	for _, n := range []string{"nvm", "conda", "oh-my-zsh", "pyenv", "rbenv"} {
		if found[n] {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return ""
	}
	return "Your startup files load " + strings.Join(names, ", ") + ", a common cause. Most of them can load only when first used."
}
